// Pinia Store for Bibframe Manager
const { defineStore } = Pinia;
import { usePluginApi } from '../composables/api.js';
import { propertySuggestions, relationships } from '../config/property-suggestions.js';

export const useBibframeStore = defineStore('bibframe', {
    state: () => ({
        baseUri: 'http://urn.fi/URN:NBN:fi:bib:',
        recordId: '',
        outputFormat: 'turtle',
        saveToDatabase: false,
        entities: [],
        error: null,
        success: null,
        generatedOutput: null,
        allTriples: [],
        
        // Property suggestions for each entity type (from bibframe_mapping.yaml)
        propertySuggestions: propertySuggestions,
        
        // All available relationships
        relationships: relationships
    }),
    
    getters: {
        getPropertySuggestions: (state) => (entityType) => {
            return state.propertySuggestions[entityType] || [];
        },
        
        // Get only property suggestions (non-relationships)
        getPropertyOnly: (state) => (entityType) => {
            const suggestions = state.propertySuggestions[entityType] || [];
            return suggestions.filter(s => s.type === 'property');
        },
        
        // Get only relationship suggestions
        getRelationshipSuggestions: (state) => (entityType) => {
            const suggestions = state.propertySuggestions[entityType] || [];
            return suggestions.filter(s => s.type === 'relationship');
        },
        
        hasEntities: (state) => state.entities.length > 0,
        
        hasOutput: (state) => state.generatedOutput !== null
    },
    
    actions: {
        addEntity(type) {
            this.entities.push({
                type: type,
                uri: '',
                properties: [],
                relationships: []
            });
        },
        
        removeEntity(index) {
            this.entities.splice(index, 1);
        },
        
        addProperty(entityIndex) {
            this.entities[entityIndex].properties.push({
                predicate: '',
                customPredicate: '',
                object: '',
                objectType: 'literal'
            });
        },
        
        removeProperty(entityIndex, propIndex) {
            this.entities[entityIndex].properties.splice(propIndex, 1);
        },
        
        addRelationship(entityIndex) {
            this.entities[entityIndex].relationships.push({
                predicate: '',
                customPredicate: '',
                targetUri: ''
            });
        },
        
        removeRelationship(entityIndex, relIndex) {
            this.entities[entityIndex].relationships.splice(relIndex, 1);
        },
        
        addPropertySuggestion(entityType, propertyValue) {
            const entityIndex = this.entities.findIndex(e => e.type === entityType);
            if (entityIndex !== -1) {
                this.entities[entityIndex].properties.push({
                    predicate: propertyValue,
                    customPredicate: '',
                    object: '',
                    objectType: 'literal'
                });
            } else {
                this.success = `Please add a ${entityType} entity first`;
                setTimeout(() => { this.success = null; }, 2000);
            }
        },

        async convertRecord(biblionumber) {
            try {
                const { convertRecordToBibframe } = usePluginApi();
                const converted = await convertRecordToBibframe(biblionumber, this.outputFormat);
                
                // Populate entities from the triplets
                if (converted.triples && converted.triples.length > 0) {
                    this.populateEntitiesFromTriples(converted.triples);
                    this.recordId = biblionumber;
                    this.generatedOutput = converted.formatted;
                    this.allTriples = converted.triples.map((t, i) => ({ ...t, id: i }));
                    this.success = converted.message || 'Record converted successfully';
                }
            } catch (err) {
                this.error = err.message || 'Failed to load record';
            }
        },
        
        populateEntitiesFromTriples(triples) {
            // Clear existing entities
            this.entities = [];
            
            // Group triples by subject
            const groupedBySubject = {};
            triples.forEach(triple => {
                if (!groupedBySubject[triple.subject]) {
                    groupedBySubject[triple.subject] = [];
                }
                groupedBySubject[triple.subject].push(triple);
            });
            
            // Create entities from grouped triples
            Object.keys(groupedBySubject).forEach(subjectUri => {
                const subjectTriples = groupedBySubject[subjectUri];
                
                // Find the rdf:type triple to determine entity type
                const typeTriple = subjectTriples.find(t => t.predicate === 'rdf:type');
                if (!typeTriple) return; // Skip if no type found
                
                // Extract entity type from bffi:Work, bffi:Expression, etc.
                const typeMatch = typeTriple.object.match(/bffi:(\w+)/);
                if (!typeMatch) return;
                
                const entityType = typeMatch[1].toLowerCase();
                
                // Create new entity
                const entity = {
                    type: entityType,
                    uri: subjectUri,
                    properties: [],
                    relationships: []
                };
                
                // Process all triples for this subject
                subjectTriples.forEach(triple => {
                    // Skip rdf:type as it's already used to determine entity type
                    if (triple.predicate === 'rdf:type') return;
                    
                    // Check if it's a relationship (URI) or property (literal)
                    if (triple.object_type === 'uri') {
                        // It's a relationship
                        entity.relationships.push({
                            predicate: triple.predicate,
                            customPredicate: '',
                            targetUri: triple.object
                        });
                    } else {
                        // It's a property
                        entity.properties.push({
                            predicate: triple.predicate,
                            customPredicate: '',
                            object: triple.object,
                            objectType: triple.object_type || 'literal'
                        });
                    }
                });
                
                this.entities.push(entity);
            });
        },
        
        setError(message) {
            this.error = message;
        },
        
        clearError() {
            this.error = null;
        },
        
        setSuccess(message) {
            this.success = message;
        },
        
        clearSuccess() {
            this.success = null;
        },
        
        generateBibframe() {
            this.error = null;
            this.generatedOutput = null;
            this.allTriples = [];
            
            if (this.entities.length === 0) {
                this.error = 'Please add at least one entity';
                return;
            }
            
            if (!this.recordId) {
                this.error = 'Please provide a Record ID';
                return;
            }
            
            // Generate triples from entities
            const triples = [];
            
            this.entities.forEach(entity => {
                const subjectUri = entity.uri || `${this.baseUri}${this.recordId}/${entity.type}`;
                
                // Add rdf:type triple
                triples.push({
                    subject: subjectUri,
                    predicate: 'rdf:type',
                    object: `bffi:${entity.type.charAt(0).toUpperCase() + entity.type.slice(1)}`,
                    objectType: 'uri'
                });
                
                // Add properties
                entity.properties.forEach(prop => {
                    if (prop.object && (prop.predicate || prop.customPredicate)) {
                        triples.push({
                            subject: subjectUri,
                            predicate: prop.predicate === 'custom' ? prop.customPredicate : prop.predicate,
                            object: prop.object,
                            objectType: prop.objectType
                        });
                    }
                });
                
                // Add relationships
                entity.relationships.forEach(rel => {
                    if (rel.targetUri && (rel.predicate || rel.customPredicate)) {
                        triples.push({
                            subject: subjectUri,
                            predicate: rel.predicate === 'custom' ? rel.customPredicate : rel.predicate,
                            object: rel.targetUri,
                            objectType: 'uri'
                        });
                    }
                });
            });
            
            this.allTriples = triples.map((t, i) => ({ ...t, id: i }));
            
            // Format output based on selected format
            if (this.outputFormat === 'turtle') {
                this.generatedOutput = this.formatAsTurtle(triples);
            } else if (this.outputFormat === 'json-ld') {
                this.generatedOutput = this.formatAsJsonLd(triples);
            } else if (this.outputFormat === 'ntriples') {
                this.generatedOutput = this.formatAsNTriples(triples);
            } else if (this.outputFormat === 'rdf-xml') {
                this.generatedOutput = this.formatRDFXML(triples);
            } else {
                this.generatedOutput = JSON.stringify(triples, null, 2);
            }
            
            this.success = 'Bibframe record generated successfully!';
        },
        
        formatAsTurtle(triples) {
            let output = '@prefix bffi: <http://urn.fi/URN:NBN:fi:schema:bffi:> .\n';
            output += '@prefix bf: <http://id.loc.gov/ontologies/bibframe/> .\n';
            output += '@prefix rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#> .\n';
            output += '@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .\n\n';
            
            const groupedTriples = {};
            triples.forEach(t => {
                if (!groupedTriples[t.subject]) {
                    groupedTriples[t.subject] = [];
                }
                groupedTriples[t.subject].push(t);
            });
            
            Object.keys(groupedTriples).forEach(subject => {
                output += `<${subject}>\n`;
                groupedTriples[subject].forEach((t, i) => {
                    const obj = t.objectType === 'uri' ? `<${t.object}>` : `"${t.object}"`;
                    const ending = i === groupedTriples[subject].length - 1 ? ' .' : ' ;';
                    output += `    ${t.predicate} ${obj}${ending}\n`;
                });
                output += '\n';
            });
            
            return output;
        },
        
        formatAsJsonLd(triples) {
            const context = {
                "@context": {
                    "bffi": "http://urn.fi/URN:NBN:fi:schema:bffi:",
                    "bf": "http://id.loc.gov/ontologies/bibframe/",
                    "rdf": "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
                }
            };
            
            const groupedTriples = {};
            
            triples.forEach(t => {
                if (!groupedTriples[t.subject]) {
                    groupedTriples[t.subject] = { "@id": t.subject };
                }
                const pred = t.predicate.replace('bffi:', '').replace('rdf:', '');
                groupedTriples[t.subject][pred] = t.objectType === 'uri' ? { "@id": t.object } : t.object;
            });
            
            context["@graph"] = Object.values(groupedTriples);
            
            return JSON.stringify(context, null, 2);
        },
        
        formatAsNTriples(triples) {
            let output = '';
            triples.forEach(t => {
                const obj = t.objectType === 'uri' ? `<${t.object}>` : `"${t.object}"`;
                output += `<${t.subject}> <${t.predicate}> ${obj} .\n`;
            });
            return output;
        },

        formatRDFXML(triples) {
            // Helper function to escape XML special characters
            const escapeXml = (str) => {
                return String(str)
                    .replace(/&/g, '&amp;')
                    .replace(/</g, '&lt;')
                    .replace(/>/g, '&gt;')
                    .replace(/"/g, '&quot;')
                    .replace(/'/g, '&apos;');
            };
            
            // Helper function to extract namespace prefix and local name
            const splitPredicate = (predicate) => {
                if (predicate.includes(':')) {
                    const [prefix, localName] = predicate.split(':');
                    return { prefix, localName };
                }
                return { prefix: 'rdf', localName: predicate };
            };
            
            // Start XML document
            let output = '<?xml version="1.0" encoding="utf-8"?>\n';
            output += '<rdf:RDF\n';
            output += '   xmlns:bffi="http://urn.fi/URN:NBN:fi:schema:bffi:"\n';
            output += '   xmlns:bf="http://id.loc.gov/ontologies/bibframe/"\n';
            output += '   xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"\n';
            output += '   xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#">\n';
            
            // Group triples by subject
            const groupedTriples = {};
            triples.forEach(t => {
                if (!groupedTriples[t.subject]) {
                    groupedTriples[t.subject] = [];
                }
                groupedTriples[t.subject].push(t);
            });
            
            // Generate RDF/XML for each subject
            Object.keys(groupedTriples).forEach(subject => {
                const {object} = groupedTriples[subject].find(t => t.predicate === 'rdf:type') || {};
                const entityType = object ? object : 'rdf:Description';
                output += `  <${entityType} rdf:about="${escapeXml(subject)}">\n`;
                const filteredTriples = groupedTriples[subject].filter(t => t.predicate !== 'rdf:type');
                
                filteredTriples.forEach(triple => {
                    const { prefix, localName } = splitPredicate(triple.predicate);
                    
                    if (triple.objectType === 'uri') {
                        // For URI objects, use rdf:resource attribute
                        output += `    <${prefix}:${localName} rdf:resource="${escapeXml(triple.object)}"/>\n`;
                    } else {
                        // For literal objects, use element content
                        // Check if object has language tag
                        const langMatch = triple.object.match(/^"(.+)"@(\w+)$/);
                        if (langMatch) {
                            output += `    <${prefix}:${localName} xml:lang="${langMatch[2]}">${escapeXml(langMatch[1])}</${prefix}:${localName}>\n`;
                        } else {
                            // Clean quotes if present
                            const cleanObject = triple.object.replace(/^"(.+)"$/, '$1');
                            output += `    <${prefix}:${localName}>${escapeXml(cleanObject)}</${prefix}:${localName}>\n`;
                        }
                    }
                });
                
                output += `  </${entityType}>\n`;
            });
            
            output += '</rdf:RDF>\n';
            
            return output;
        },
        
        resetForm() {
            if (confirm('Are you sure you want to reset? All data will be lost.')) {
                this.entities = [];
                this.recordId = '';
                this.generatedOutput = null;
                this.allTriples = [];
                this.success = 'Form reset';
                this.generateRecordId();
            }
        },
        
        generateRecordId() {
            this.recordId = 'bffi-' + Math.random().toString(36).substr(2, 9);
        }
    }
});
